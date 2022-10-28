defmodule Membrane.RTP.OutboundTrackingSerializer do
  @moduledoc """
  Tracks statistics of outbound packets.

  Besides tracking statistics, tracker can also serialize packet's header and payload stored inside an incoming buffer
  into a proper RTP packet. When encountering header extensions, it remaps its identifiers from locally used extension
  names to integer values expected by the receiver.
  """
  use Membrane.Filter

  require Membrane.Logger
  alias Membrane.RTCP.FeedbackPacket.{FIR, PLI}
  alias Membrane.RTP.Session.SenderReport
  alias Membrane.{Buffer, Payload, RemoteStream, RTCPEvent, RTP, Time}

  @padding_packet_size 256

  def_input_pad :input, caps: RTP, demand_mode: :auto

  def_output_pad :output,
    caps: {RemoteStream, type: :packetized, content_format: RTP},
    demand_mode: :auto

  def_input_pad :rtcp_input,
    availability: :on_request,
    caps: :any,
    demand_mode: :auto

  def_output_pad :rtcp_output,
    availability: :on_request,
    caps: {RemoteStream, type: :packetized, content_format: RTCP},
    demand_mode: :auto

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

    alias Membrane.RTP

    @type t :: %__MODULE__{
            ssrc: RTP.ssrc_t(),
            payload_type: RTP.payload_type_t(),
            extension_mapping: RTP.SessionBin.rtp_extension_mapping_t(),
            alignment: pos_integer(),
            any_buffer_sent?: boolean(),
            rtcp_output_pad: Membrane.Pad.ref_t() | nil,
            stats_acc: %{}
          }

    defstruct ssrc: 0,
              payload_type: 0,
              extension_mapping: %{},
              alignment: 1,
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
    state =
      %State{}
      |> put_in([:stats_acc, :clock_rate], options.clock_rate)
      |> Map.merge(options |> Map.from_struct() |> Map.drop([:clock_rate]))

    {:ok, state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:rtcp_input, _id), _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_pad_added(
        Pad.ref(:rtcp_output, _id) = pad,
        %{playback: :playing},
        %{rtcp_output_pad: nil} = state
      ) do
    caps = %RemoteStream{type: :packetized, content_format: RTCP}
    {{:ok, caps: {pad, caps}}, %{state | rtcp_output_pad: pad}}
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
  def handle_caps(:input, _caps, _ctx, state) do
    caps = %RemoteStream{type: :packetized, content_format: RTP}
    {{:ok, caps: {:output, caps}}, state}
  end

  @impl true
  def handle_caps(_pad, _caps, _ctx, state) do
    {:ok, state}
  end

  @impl true
  def handle_event(
        Pad.ref(:rtcp_input, _id),
        %RTCPEvent{rtcp: %{payload: %keyframe_request{}}},
        _ctx,
        state
      )
      when keyframe_request in [PLI, FIR] do
    # PLI or FIR reaching OutboundTrackingSerializer means the receiving peer sent it
    # We need to pass it to the sending peer's RTCP.Receiver (in StreamReceiveBin) to get translated again into FIR/PLI with proper SSRCs
    # and then sent to the sender. So the KeyframeRequestEvent, like salmon, starts an upstream journey here trying to reach that peer.
    {{:ok, event: {:input, %Membrane.KeyframeRequestEvent{}}}, state}
  end

  @impl true
  def handle_event(pad, event, ctx, state) do
    super(pad, event, ctx, state)
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    if state.rtcp_output_pad do
      caps = %RemoteStream{type: :packetized, content_format: RTCP}
      {{:ok, caps: {state.rtcp_output_pad, caps}}, state}
    else
      {:ok, state}
    end
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

    is_padding_packet? = Map.get(rtp_metadata, :is_padding?, false)

    if is_padding_packet? and buffer.payload != <<>> do
      raise "Incorrect padding packet. Padding packets must have empty payload"
    end

    header =
      struct(RTP.Header, %{
        rtp_metadata
        | ssrc: state.ssrc,
          payload_type: state.payload_type,
          extensions: extensions
      })

    payload =
      RTP.Packet.serialize(%RTP.Packet{header: header, payload: buffer.payload},
        align_to: if(is_padding_packet?, do: @padding_packet_size, else: state.alignment)
      )

    buffer = %Buffer{buffer | payload: payload, metadata: metadata}

    {{:ok, buffer: {:output, buffer}}, %{state | any_buffer_sent?: true}}
  end

  @impl true
  def handle_other(:send_stats, ctx, state) do
    %{rtcp_output_pad: rtcp_output} = state

    if rtcp_output && not ctx.pads[rtcp_output].end_of_stream? do
      stats = get_stats(state)

      actions =
        %{state.ssrc => stats}
        |> SenderReport.generate_report()
        |> Enum.map(&Membrane.RTCP.Packet.serialize(&1))
        |> Enum.map(&{:buffer, {rtcp_output, %Membrane.Buffer{payload: &1}}})

      {{:ok, actions}, %{state | any_buffer_sent?: false}}
    else
      {:ok, state}
    end
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
