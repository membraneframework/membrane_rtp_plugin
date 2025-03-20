defmodule Membrane.RTP.Muxer do
  @moduledoc """
  Element that combines multiple streams into a single RTP stream. 

  Each new input stream is assigned a unique SSRC that the packets transporting this stream will have. 
  The demuxer will try to resolve what `payload_type` and `clock_rate` should be assumed based on the 
  incoming stream format and passed pad options. 
  Timestamps are calculated based on assumed `clock_rate`.
  """
  use Membrane.Filter

  require Membrane.Pad

  alias Membrane.{Pad, RemoteStream, RTP}

  @max_ssrc Bitwise.bsl(1, 32) - 1
  @max_sequence_number Bitwise.bsl(1, 16) - 1
  @max_timestamp Bitwise.bsl(1, 32) - 1

  @payload_format_to_encoding_name %{
    Membrane.H264 => :H264,
    Membrane.H265 => :H265,
    Membrane.VP8 => :VP8,
    Membrane.AAC => :AAC,
    Membrane.Opus => :opus,
    Membrane.MPEGAudio => :MPA
  }

  def_input_pad :input,
    accepted_format: RTP,
    availability: :on_request,
    options: [
      ssrc: [
        spec: RTP.ssrc() | :random,
        default: :random,
        description: """
        SSRC that this stream will be assigned. If not provided, a random free value will be assigned.
        """
      ],
      payload_type: [
        spec: RTP.payload_type() | nil,
        default: nil,
        description: """
        Payload type of the stream. If not provided, determined from the resolved encoding name.
        """
      ],
      encoding: [
        spec: RTP.encoding_name() | nil,
        default: nil,
        description: """
        Encoding name of the stream that will be used if the muxer fails to infer it from incoming stream format. 
        Used for determining payload_type, if it wasn't provided.
        """
      ],
      clock_rate: [
        spec: non_neg_integer() | nil,
        default: nil,
        description: """
        Clock rate to use. If not provided, determined from resolved payload type.
        """
      ]
    ]

  def_output_pad :output, accepted_format: %RemoteStream{type: :packetized, content_format: RTP}

  def_options use_srtp: [
                spec: false | {true, [ExLibSRTP.Policy.t()]},
                default: false,
                description: """
                Specifies whether to use SRTP. Requires adding [srtp](https://github.com/membraneframework/elixir_libsrtp) dependency to work.
                If set to true also takes a list of SRTP policies to use for decrypting packets. See `t:ExLibSRTP.Policy.t/0` for details.
                """
              ]

  defmodule State do
    @moduledoc false
    defmodule StreamState do
      @moduledoc false
      alias Membrane.RTP

      @type t :: %__MODULE__{
              ssrc: RTP.ssrc(),
              sequence_number: ExRTP.Packet.uint16(),
              initial_timestamp: ExRTP.Packet.uint32(),
              clock_rate: RTP.clock_rate(),
              payload_type: RTP.payload_type(),
              end_of_stream: boolean()
            }

      @enforce_keys [:ssrc, :sequence_number, :initial_timestamp, :clock_rate, :payload_type]

      defstruct @enforce_keys ++ [end_of_stream: false]
    end

    @type t :: %__MODULE__{
            stream_states: %{Pad.ref() => StreamState.t()},
            srtp: RTP.SRTP.Wrapper.t()
          }

    @enforce_keys [:srtp]
    defstruct @enforce_keys ++ [stream_states: %{}]
  end

  @impl true
  def handle_init(_ctx, opts) do
    srtp =
      case opts.use_srtp do
        false -> nil
        {true, policies} -> RTP.SRTP.Wrapper.initialize(policies)
      end

    {[], %State{srtp: srtp}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[stream_format: {:output, %RemoteStream{type: :packetized, content_format: RTP}}], state}
  end

  @impl true
  def handle_stream_format(pad, stream_format, ctx, state) do
    pad_options = ctx.pads[pad].options

    ssrc = get_stream_ssrc(pad_options.ssrc, state)

    encoding_name =
      @payload_format_to_encoding_name[stream_format.payload_format] ||
        pad_options.encoding

    %{payload_type: payload_type, clock_rate: clock_rate} =
      RTP.PayloadFormat.resolve(
        encoding_name: encoding_name,
        payload_type: pad_options.payload_type,
        clock_rate: pad_options.clock_rate
      )

    if payload_type == nil do
      raise "Could not resolve payload type, information provided via pad options and stream format not sufficient"
    end

    if clock_rate == nil do
      raise "Could not resolve clock rate, information provided via pad options and stream format not sufficient"
    end

    new_stream_state = %State.StreamState{
      ssrc: ssrc,
      sequence_number: Enum.random(0..@max_sequence_number),
      initial_timestamp: Enum.random(0..@max_timestamp),
      clock_rate: clock_rate,
      payload_type: payload_type
    }

    state = put_in(state.stream_states[pad], new_stream_state)

    {[], state}
  end

  @impl true
  def handle_buffer(Pad.ref(:input, _ref) = pad_ref, buffer, _ctx, state) do
    rtp_metadata = Map.get(buffer.metadata, :rtp, %{})
    stream_state = state.stream_states[pad_ref]

    rtp_offset =
      buffer.pts
      |> Membrane.Time.as_seconds()
      |> Numbers.mult(stream_state.clock_rate)
      |> Ratio.trunc()

    timestamp = rem(stream_state.initial_timestamp + rtp_offset, @max_timestamp + 1)
    sequence_number = rem(stream_state.sequence_number + 1, @max_sequence_number + 1)

    state = put_in(state.stream_states[pad_ref].sequence_number, sequence_number)

    buffer_action =
      ExRTP.Packet.new(buffer.payload,
        payload_type: stream_state.payload_type,
        sequence_number: sequence_number,
        timestamp: timestamp,
        ssrc: stream_state.ssrc,
        csrc: Map.get(rtp_metadata, :csrcs, []),
        marker: Map.get(rtp_metadata, :marker, false)
      )
      |> payload_packet(buffer, state)

    {buffer_action, state}
  end

  @impl true
  def handle_end_of_stream(Pad.ref(:input, _ref) = pad_ref, _ctx, state) do
    state = put_in(state.stream_states[pad_ref].end_of_stream, true)

    if Enum.all?(Enum.map(state.stream_states, fn {_pad_ref, %{end_of_stream: eos}} -> eos end)) do
      {[end_of_stream: :output], state}
    else
      {[], state}
    end
  end

  @spec payload_packet(ExRTP.Packet.t(), Membrane.Buffer.t(), State.t()) ::
          [Membrane.Element.Action.t()]
  defp payload_packet(packet, original_buffer, state) do
    raw_packet = ExRTP.Packet.encode(packet)

    case state.srtp do
      nil -> raw_packet
      srtp -> RTP.SRTP.Wrapper.protect(srtp, raw_packet)
    end
    |> case do
      nil ->
        []

      rtp_packet ->
        buffer = %Membrane.Buffer{
          original_buffer
          | payload: rtp_packet,
            metadata: Map.put(original_buffer.metadata, :rtp, %{packet | payload: <<>>})
        }

        [buffer: {:output, buffer}]
    end
  end

  @spec get_stream_ssrc(RTP.ssrc() | :random, State.t()) :: RTP.ssrc()
  defp get_stream_ssrc(ssrc, state) do
    assigned_ssrcs = Enum.map(state.stream_states, fn {_pad_ref, %{ssrc: ssrc}} -> ssrc end)

    case ssrc do
      :random ->
        Stream.repeatedly(fn -> Enum.random(0..@max_ssrc) end)
        |> Enum.find(&(&1 not in assigned_ssrcs))

      provided_ssrc ->
        if provided_ssrc in assigned_ssrcs do
          raise("SSRC #{provided_ssrc} already assigned to a different stream")
        end

        provided_ssrc
    end
  end
end
