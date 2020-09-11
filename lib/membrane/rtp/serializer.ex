defmodule Membrane.RTP.Serializer do
  use Membrane.Filter

  alias Membrane.{Buffer, RTP}

  @max_seq_num 65535

  def_input_pad :input, caps: RTP, demand_unit: :buffers
  def_output_pad :output, caps: :any

  def_options ssrc: [], alignment: [default: 1]

  @impl true
  def handle_init(options) do
    state = %{sequence_number: Enum.random(0..@max_seq_num)}
    {:ok, Map.merge(Map.from_struct(options), state)}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, %Buffer{payload: payload, metadata: metadata}, ctx, state) do
    {rtp_metadata, metadata} = Map.pop(metadata, :rtp, %{})

    header = %RTP.Header{
      ssrc: state.ssrc,
      marker: Map.get(rtp_metadata, :marker, false),
      payload_type: ctx.pads.input.caps.payload_type,
      timestamp: rtp_metadata.timestamp,
      sequence_number: state.sequence_number,
      csrcs: Map.get(rtp_metadata, :csrcs, [])
    }

    packet = %RTP.Packet{header: header, payload: payload}
    payload = RTP.Packet.serialize(packet, align_to: state.alignment)
    buffer = %Buffer{payload: payload, metadata: metadata}
    state = Map.update!(state, :sequence_number, &rem(&1 + 1, @max_seq_num + 1))
    {{:ok, buffer: {:output, buffer}}, state}
  end
end
