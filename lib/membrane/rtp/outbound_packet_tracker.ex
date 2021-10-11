defmodule Membrane.RTP.OutboundPacketTracker do
  @moduledoc """
  Tracks statistics of outband packets.

  Besides tracking statistics, tracker can also serialize packet's header and payload stored inside an incoming buffer into
  a a proper RTP packet.
  """
  use Membrane.Filter

  alias Membrane.{Buffer, RTP, Payload, Time}

  def_input_pad :input,
    caps: :any,
    demand_unit: :buffers

  def_output_pad :output,
    caps: :any

  def_options ssrc: [spec: RTP.ssrc_t()],
              payload_type: [spec: RTP.payload_type_t()],
              clock_rate: [spec: RTP.clock_rate_t()],
              serialize_packets?: [
                spec: boolean(),
                default: false,
                description: """
                Decides if incoming buffers should get serialized to RTP packets.
                If set to true then the filter assumes that buffer's metadata has proper header information under `:rtp` key
                and buffer's payload is a proper RTP payload.

                Packet serialization may be necessary when there is no payloading process applied and we receive buffers with
                parsed header and proper payload and we need to concatenate them.
                """
              ],
              alignment: [
                default: 1,
                spec: pos_integer(),
                description: """
                Number of bytes that each packet should be aligned to.
                Alignment is achieved by adding RTP padding.
                """
              ]

  defmodule State do
    @moduledoc false
    use Bunch.Access

    @type t :: %__MODULE__{
            any_buffer_sent?: boolean(),
            stats_acc: %{}
          }

    defstruct any_buffer_sent?: false,
              serialize_packets?: false,
              stats_acc: %{
                clock_rate: 0,
                timestamp: 0,
                rtp_timestamp: 0,
                sender_packet_count: 0,
                sender_octet_count: 0
              }
  end

  @impl true
  def handle_init(options) do
    state = %State{serialize_packets?: options.serialize_packets?}

    state = state |> put_in([:stats_acc, :clock_rate], options.clock_rate)
    {:ok, Map.merge(Map.from_struct(options), state)}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_process(:input, %Buffer{} = buffer, _ctx, state) do
    state = update_stats(buffer, state)

    {{:ok, buffer: {:output, process_buffer(buffer, state)}}, state}
  end

  @impl true
  def handle_other(:send_stats, _ctx, state) do
    stats = get_stats(state)
    state = %{state | any_buffer_sent?: false}
    {{:ok, notify: {:outband_stats, stats}}, state}
  end

  @spec get_stats(State.t()) :: map() | :no_stats
  defp get_stats(%State{any_buffer_sent?: false}), do: :no_stats
  defp get_stats(%State{stats_acc: stats}), do: stats

  defp update_stats(%Buffer{payload: payload, metadata: metadata}, state) do
    %{
      sender_octet_count: octet_count,
      sender_packet_count: packet_count
    } = state.stats_acc

    updated_stats = %{
      clock_rate: state.stats_acc.clock_rate,
      sender_octet_count: octet_count + Payload.size(payload),
      sender_packet_count: packet_count + 1,
      timestamp: Time.vm_time(),
      rtp_timestamp: metadata.rtp.timestamp
    }

    Map.put(state, :stats_acc, updated_stats)
  end

  defp process_buffer(buffer, %{serialize_packets?: true, ssrc: ssrc}) do
    header = struct(RTP.Header, %{buffer.metadata.rtp | ssrc: ssrc})
    payload = RTP.Packet.serialize(%RTP.Packet{header: header, payload: buffer.payload})

    %Buffer{buffer | payload: payload}
  end

  defp process_buffer(buffer, _state), do: buffer
end