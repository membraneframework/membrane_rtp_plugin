defmodule Membrane.RTP.OutbandPacketTracker do
  @moduledoc """
  Tracks statistics of outband packets.
  """
  use Membrane.Filter

  alias Membrane.{Buffer, RTP, RemoteStream, Payload, Time}

  def_input_pad :input,
    caps: {RemoteStream, type: :packetized, content_format: one_of([nil, RTP])},
    demand_unit: :buffers

  def_output_pad :output,
    caps: {RemoteStream, type: :packetized, content_format: one_of([nil, RTP])}

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
    @moduledoc false
    use Bunch.Access

    @type t :: %__MODULE__{
            any_buffer_sent?: boolean(),
            stats_acc: %{}
          }

    defstruct any_buffer_sent?: false,
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
    state = %State{}

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

    {{:ok, buffer: {:output, buffer}}, state}
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
end
