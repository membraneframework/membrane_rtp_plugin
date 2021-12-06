defmodule Membrane.RTP.OutboundPacketTracker do
  @moduledoc """
  Tracks statistics of outbound packets.

  Besides tracking statistics, tracker can also serialize packet's header and payload stored inside an incoming buffer
  into a proper RTP packet. When encountering header extensions, it remaps its identifiers from locally used extension
  names to integer values expected by the receiver.
  """
  use Membrane.Filter

  alias Membrane.{Buffer, RTP, Payload, Time}
  alias Membrane.RTP.Session.SenderReport

  def_input_pad :input,
    caps: :any,
    demand_unit: :buffers

  def_output_pad :output,
    caps: :any

  def_input_pad :rtcp_input,
    availability: :on_request,
    caps: :any,
    demand_unit: :buffers

  def_output_pad :rtcp_output, availability: :on_request, caps: :any

  def_options ssrc: [spec: RTP.ssrc_t()],
              payload_type: [spec: RTP.payload_type_t()],
              clock_rate: [spec: RTP.clock_rate_t()],
              extension_mapping: [spec: RTP.SessionBin.rtp_extension_mapping_t()],
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
            ssrc: RTP.ssrc_t(),
            any_buffer_sent?: boolean(),
            stats_acc: %{}
          }

    defstruct ssrc: 0,
              any_buffer_sent?: false,
              rtcp_output_pad: nil,
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
    state = %State{} |> put_in([:stats_acc, :clock_rate], options.clock_rate)

    {:ok, Map.merge(Map.from_struct(options), state)}
  end

  @impl true
  def handle_demand(:output, size, :buffers, _ctx, state) do
    {{:ok, demand: {:input, size}}, state}
  end

  @impl true
  def handle_demand(Pad.ref(:rtcp_output, _id), _size, _type, _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtcp_input, _id), _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtcp_output, _id) = pad, _ctx, %{rtcp_output_pad: nil} = state) do
    {:ok, %{state | rtcp_output_pad: pad}}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtcp_output, _id), _ctx, _state) do
    raise "rtcp_output pad can get linked just once"
  end

  @impl true
  def handle_process(:input, %Buffer{} = buffer, _ctx, state) do
    state = update_stats(buffer, state)

    {rtp_metadata, metadata} = Map.pop(buffer.metadata, :rtp, %{})

    supported_extensions = Map.keys(state.extension_mapping)

    extensions =
      rtp_metadata.extensions
      |> Enum.filter(fn extension -> extension.identifier in supported_extensions end)
      |> Enum.map(fn extension ->
        %{extension | identifier: Map.fetch!(state.extension_mapping, extension.identifier)}
      end)

    header =
      struct(RTP.Header, %{
        rtp_metadata
        | ssrc: state.ssrc,
          payload_type: state.payload_type,
          extensions: extensions
      })

    payload =
      RTP.Packet.serialize(%RTP.Packet{header: header, payload: buffer.payload},
        align_to: state.alignment
      )

    buffer = %Buffer{buffer | payload: payload, metadata: metadata}

    {{:ok, buffer: {:output, buffer}}, %{state | any_buffer_sent?: true}}
  end

  @impl true
  def handle_other(:send_stats, _ctx, %{rtcp_output_pad: nil} = state) do
    {:ok, state}
  end

  @impl true
  def handle_other(:send_stats, _ctx, state) do
    stats = get_stats(state)

    actions =
      %{state.ssrc => stats}
      |> SenderReport.generate_report()
      |> Enum.map(&Membrane.RTCP.Packet.serialize(&1))
      |> Enum.map(&{:buffer, {state.rtcp_output_pad, %Membrane.Buffer{payload: &1}}})

    {{:ok, actions ++ [redemand: state.rtcp_output_pad]}, %{state | any_buffer_sent?: false}}
  end

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
