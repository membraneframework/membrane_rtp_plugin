defmodule Membrane.RTP.Serializer do
  @moduledoc """
  Serializes RTP payload to RTP packets.
  """
  use Membrane.Filter

  alias Membrane.{Buffer, RTP, Stream, Payload}

  @max_seq_num 65535
  @max_timestamp 0xFFFFFFFF
  @max_sender_octet_count 0xFFFFFFFF

  def_input_pad :input, caps: RTP, demand_unit: :buffers
  def_output_pad :output, caps: {Stream, type: :packet_stream, content: RTP}

  def_options ssrc: [spec: RTP.ssrc_t()],
              payload_type: [spec: RTP.payload_type_t()],
              clock_rate: [spec: RTP.clock_rate_t()],
              alignment: [
                default: 1,
                spec: pos_integer(),
                description: """
                Number of bytes that each packet should be aligned to.
                Alignment is achieved by adding RTP padding.
                """
              ]

  defmodule State do
    defstruct sequence_number: 0,
              init_timestamp: 0,
              any_buffer_sent?: false,
              stats_acc: %{
                senders_packet_count: 0,
                senders_octet_count: 0
              }

    @type t :: %__MODULE__{
            sequence_number: non_neg_integer(),
            init_timestamp: non_neg_integer(),
            any_buffer_sent?: boolean(),
            stats_acc: %{
              senders_packet_count: non_neg_integer(),
              senders_octet_count: non_neg_integer()
            }
          }
  end

  @impl true
  def handle_init(options) do
    state = %State{
      sequence_number: Enum.random(0..@max_seq_num),
      init_timestamp: Enum.random(0..@max_timestamp)
    }

    {:ok, Map.merge(Map.from_struct(options), state)}
  end

  @impl true
  def handle_caps(:input, _caps, _ctx, state) do
    caps = %Stream{type: :packet_stream, content: RTP}
    {{:ok, caps: {:output, caps}}, state}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, %Buffer{payload: payload, metadata: metadata}, _ctx, state) do
    {rtp_metadata, metadata} = Map.pop(metadata, :rtp, %{})
    %{timestamp: timestamp} = metadata
    rtp_offset = timestamp |> Ratio.mult(state.clock_rate) |> Membrane.Time.to_seconds()
    rtp_timestamp = rem(state.init_timestamp + rtp_offset, @max_timestamp + 1)

    header = %RTP.Header{
      ssrc: state.ssrc,
      marker: Map.get(rtp_metadata, :marker, false),
      payload_type: state.payload_type,
      timestamp: rtp_timestamp,
      sequence_number: state.sequence_number,
      csrcs: Map.get(rtp_metadata, :csrcs, [])
    }

    packet = %RTP.Packet{header: header, payload: payload}
    payload = RTP.Packet.serialize(packet, align_to: state.alignment)
    buffer = %Buffer{payload: payload, metadata: metadata}
    state = Map.update!(state, :sequence_number, &rem(&1 + 1, @max_seq_num + 1))
    state = Map.update!(state, :any_buffer_sent?, &(&1 or true))
    {{:ok, buffer: {:output, buffer}}, state}
  end

  @impl true
  def handle_other(:send_stats, _ctx, state) do
    {stats, state} = get_updated_stats(state)
    {{:ok, notify: {:serializer_stats, stats}}, state}
  end

  defp get_updated_stats(%State{any_buffer_sent?: false} = state) do
    {:no_stats, state}
  end

  defp get_updated_stats(%State{stats_acc: stats} = state) do
    {stats, state}
  end

  defp update_counters(%Buffer{payload: payload}, state) do
    if rem(state.stats_acc.sender_octet_count + Payload.size(payload), @max_sender_octet_count) <
         state.stats_acc.sender_octet_count do
      state
      |> put_in([:stats_acc, :sender_octet_count], 0)
      |> put_in([:stats_acc, :sender_packet_count], 0)
    else
      state
      |> put_in(
        [:stats_acc, :sender_octet_count],
        state.stats_acc.sender_octet_count + Payload.size(payload)
      )
      |> put_in([:stats_acc, :sender_packet_count], state.stats_acc.sender_packet_count + 1)
    end
  end
end
