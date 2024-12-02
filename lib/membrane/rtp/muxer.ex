defmodule Membrane.RTP.Muxer do
  @moduledoc false
  use Membrane.Filter

  require Membrane.Pad

  alias Membrane.{Pad, RemoteStream, RTCP, RTP}

  @max_ssrc Bitwise.bsl(1, 32) - 1
  @max_sequence_number Bitwise.bsl(1, 16) - 1
  @max_timestamp Bitwise.bsl(1, 32) - 1

  def_input_pad :input,
    accepted_format: RTP,
    availability: :on_request,
    options: [
      payload_type: [
        spec: RTP.payload_type() | nil,
        default: nil,
        description: """
        Payload type of output stream. If not provided, determined from `:encoding`.
        """
      ],
      encoding: [
        spec: RTP.encoding_name() | nil,
        default: nil,
        description: """
        Encoding name of output stream. If not provided, determined from `:payload_type`.
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

  def_output_pad :output,
    accepted_format:
      %RemoteStream{type: :packetized, content_format: cf} when cf in [RTP, RTCP, nil]

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            stream_states: %{
              Pad.ref() => %{
                ssrc: RTP.ssrc(),
                sequence_number: ExRTP.Packet.uint16(),
                initial_timestamp: ExRTP.Packet.uint32(),
                clock_rate: RTP.clock_rate(),
                payload_type: RTP.payload_type()
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
    ssrc =
      fn -> Enum.random(0..@max_ssrc) end
      |> Stream.repeatedly()
      |> Enum.find(
        &(&1 not in Enum.map(state.stream_states, fn {_pad_ref, %{ssrc: ssrc}} -> ssrc end))
      )

    pad_options = ctx.pads[pad_ref].options

    {clock_rate, payload_type} =
      resolve_payload_format(
        pad_options.encoding_name,
        pad_options.clock_rate,
        pad_options.payload_type
      )

    new_stream_state = %{
      ssrc: ssrc,
      sequence_number: Enum.random(0..@max_sequence_number),
      timestamp: Enum.random(0..@max_timestamp),
      clock_rate: clock_rate,
      payload_type: payload_type
    }

    state =
      state
      |> Bunch.Struct.put_in([:stream_states, pad_ref], new_stream_state)

    {[], state}
  end

  @impl true
  def handle_buffer(Pad.ref(:input, _ref) = pad_ref, buffer, _ctx, state) do
    {rtp_metadata, metadata} = Map.pop(buffer.metadata, :rtp, %{})
    stream_state = state.stream_states[pad_ref]

    rtp_offset =
      buffer.pts
      |> Membrane.Time.as_seconds(:round)
      |> Numbers.mult(stream_state.clock_rate)

    timestamp = rem(stream_state.initial_timestamp + rtp_offset, @max_timestamp + 1)
    sequence_number = rem(stream_state.sequence_number + 1, @max_sequence_number + 1)

    state =
      Bunch.Struct.update_in(
        state,
        [:stream_states, pad_ref],
        &rem(&1 + 1, @max_sequence_number + 1)
      )

    header =
      ExRTP.Packet.new(<<>>,
        payload_type: stream_state.payload_type,
        sequence_number: sequence_number,
        timestamp: timestamp,
        ssrc: stream_state.ssrc,
        csrc: Map.get(rtp_metadata, :csrcs, []),
        marker: Map.get(rtp_metadata, :marker, false)
      )

    buffer = %Membrane.Buffer{buffer | metadata: Map.put(metadata, :rtp, header)}
    {[buffer: {:output, buffer}], state}
  end

  @spec resolve_payload_format(
          RTP.encoding_name() | nil,
          RTP.clock_rate() | nil,
          RTP.payload_type() | nil
        ) :: {RTP.clock_rate(), RTP.payload_type()}
  defp resolve_payload_format(encoding_name, clock_rate, payload_type) do
    payload_type =
      case {encoding_name, payload_type} do
        {nil, nil} ->
          raise "Neither encoding name, nor payload type provided"

        {encoding_name, nil} ->
          %{payload_type: default_payload_type} = RTP.PayloadFormat.get(encoding_name)

          if default_payload_type == nil do
            raise "Payload type not provided with no default value registered"
          end

          default_payload_type

        {_encoding_name, payload_type} ->
          payload_type
      end

    payload_type_mapping = RTP.PayloadFormat.get_payload_type_mapping(payload_type)

    clock_rate =
      case {clock_rate, payload_type_mapping} do
        {nil, %{clock_rate: default_clock_rate}} -> default_clock_rate
        {nil, %{}} -> raise "Clock rate not provided with no default value registered"
        {clock_rate, _payload_type_mapping} -> clock_rate
      end

    {clock_rate, payload_type}
  end
end
