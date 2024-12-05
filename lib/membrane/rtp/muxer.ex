defmodule Membrane.RTP.Muxer do
  @moduledoc false
  use Membrane.Filter

  require Membrane.Pad

  alias Membrane.{Pad, RemoteStream, RTP}

  @max_ssrc Bitwise.bsl(1, 32) - 1
  @max_sequence_number Bitwise.bsl(1, 16) - 1
  @max_timestamp Bitwise.bsl(1, 32) - 1

  def_input_pad :input,
    accepted_format: RTP,
    availability: :on_request,
    options: [
      ssrc: [
        spec: RTP.ssrc() | :random,
        default: :random,
        description: """
        SSRC that this stream will be assigned. If not present, a random free value will be assigned.
        """
      ],
      payload_type: [
        spec: RTP.payload_type() | nil,
        default: nil,
        description: """
        Payload type of the stream. If not provided, determined from `:encoding`.
        """
      ],
      encoding: [
        spec: RTP.encoding_name() | nil,
        default: nil,
        description: """
        Encoding name of the stream. Used for determining payload_type, it it wasn't provided.
        """
      ],
      clock_rate: [
        spec: non_neg_integer() | nil,
        default: nil,
        description: """
        Clock rate to use. If not provided, determined from `:payload_type`.
        """
      ]
    ]

  def_output_pad :output, accepted_format: %RemoteStream{type: :packetized, content_format: RTP}

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            stream_states: %{
              Pad.ref() => %{
                ssrc: RTP.ssrc(),
                sequence_number: ExRTP.Packet.uint16(),
                initial_timestamp: ExRTP.Packet.uint32(),
                clock_rate: RTP.clock_rate(),
                payload_type: RTP.payload_type(),
                end_of_stream: boolean()
              }
            }
          }

    @enforce_keys []
    defstruct @enforce_keys ++ [stream_states: %{}, pad_ref_to_ssrc: %{}]
  end

  @impl true
  def handle_init(_ctx, _opts) do
    {[], %State{}}
  end

  @impl true
  def handle_pad_added(Pad.ref(:input, _ref) = pad_ref, ctx, state) do
    pad_options = ctx.pads[pad_ref].options

    ssrc =
      case pad_options.ssrc do
        :random ->
          Stream.repeatedly(fn -> Enum.random(0..@max_ssrc) end)
          |> Enum.find(
            &(&1 not in Enum.map(state.stream_states, fn {_pad_ref, %{ssrc: ssrc}} -> ssrc end))
          )

        provided_ssrc ->
          if provided_ssrc in Enum.map(state.stream_states, fn {_pad_ref, %{ssrc: ssrc}} ->
               ssrc
             end),
             do: raise("SSRC #{provided_ssrc} already assigned to a different stream")

          provided_ssrc
      end

    {_payload_format, payload_type, clock_rate} =
      RTP.PayloadFormat.resolve(
        encoding_name: pad_options.encoding,
        payload_type: pad_options.payload_type,
        clock_rate: pad_options.clock_rate
      )

    new_stream_state = %{
      ssrc: ssrc,
      sequence_number: Enum.random(0..@max_sequence_number),
      initial_timestamp: Enum.random(0..@max_timestamp),
      clock_rate: clock_rate,
      payload_type: payload_type,
      end_of_stream: false
    }

    state = Bunch.Struct.put_in(state, [:stream_states, pad_ref], new_stream_state)

    {[], state}
  end

  @impl true
  def handle_playing(_ctx, state) do
    {[stream_format: {:output, %RemoteStream{type: :packetized, content_format: RTP}}], state}
  end

  @impl true
  def handle_stream_format(_pad, _stream_format, _ctx, state) do
    {[], state}
  end

  @impl true
  def handle_buffer(Pad.ref(:input, _ref) = pad_ref, buffer, _ctx, state) do
    {rtp_metadata, metadata} = Map.pop(buffer.metadata, :rtp, %{})
    stream_state = state.stream_states[pad_ref]

    rtp_offset =
      buffer.pts
      |> Membrane.Time.as_seconds()
      |> Numbers.mult(stream_state.clock_rate)
      |> Ratio.trunc()

    timestamp = rem(stream_state.initial_timestamp + rtp_offset, @max_timestamp + 1)
    sequence_number = rem(stream_state.sequence_number + 1, @max_sequence_number + 1)

    state =
      Bunch.Struct.put_in(state, [:stream_states, pad_ref, :sequence_number], sequence_number)

    packet =
      ExRTP.Packet.new(buffer.payload,
        payload_type: stream_state.payload_type,
        sequence_number: sequence_number,
        timestamp: timestamp,
        ssrc: stream_state.ssrc,
        csrc: Map.get(rtp_metadata, :csrcs, []),
        marker: Map.get(rtp_metadata, :marker, false)
      )

    raw_packet = ExRTP.Packet.encode(packet)

    buffer = %Membrane.Buffer{
      buffer
      | payload: raw_packet,
        metadata: Map.put(metadata, :rtp, %{packet | payload: <<>>})
    }

    {[buffer: {:output, buffer}], state}
  end

  @impl true
  def handle_end_of_stream(Pad.ref(:input, _ref) = pad_ref, _ctx, state) do
    state = Bunch.Struct.put_in(state, [:stream_states, pad_ref, :end_of_stream], true)

    if Enum.all?(Enum.map(state.stream_states, fn {_pad_ref, %{end_of_stream: eos}} -> eos end)) do
      {[end_of_stream: :output], state}
    else
      {[], state}
    end
  end
end
